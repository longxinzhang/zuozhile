import { BORDER_GLASS, GLASS, GLASS_SOFT, INK, MUTED, SHADOW_CARD } from '../theme/ZuozhiTheme';

@Component
export struct PostureMetricTile {
  @Prop title: string = '';
  @Prop status: string = '';
  @Prop color: string = MUTED;
  @Prop softColor: string = GLASS_SOFT;
  @Prop label: string = '';
  @Prop value: string = '--';
  @Prop icon: Resource = $rawfile('assets/posture/01_posture_straighten_correct.png');

  build() {
    Column({ space: 7 }) {
      Row({ space: 4 }) {
        Text(this.title).fontSize(13).fontColor(MUTED)
        Blank()
        Text(this.status)
          .fontSize(10)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.color)
          .padding({ left: 6, right: 6, top: 4, bottom: 4 })
          .backgroundColor(this.softColor)
          .borderRadius(8)
          .maxLines(1)
      }.width('100%')
      Image(this.icon).width(38).height(40).objectFit(ImageFit.Contain)
      Text(this.label).fontSize(12).fontColor(INK).maxLines(2).height(32).lineHeight(16)
      Text(this.value)
        .fontSize(22)
        .minFontSize(16)
        .maxFontSize(22)
        .maxLines(1)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.color)
    }
    .height(158)
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.SpaceBetween)
    .padding(12)
    .backgroundColor(GLASS)
    .borderRadius(20)
    .border({ width: 1, color: BORDER_GLASS })
    .shadow({ radius: 14, color: SHADOW_CARD, offsetY: 5 })
  }
}
