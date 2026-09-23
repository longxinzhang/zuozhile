import { GLASS, GLASS_SOFT, INK, MUTED } from '../theme/ZuozhiTheme';

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
    Column({ space: 6 }) {
      Row({ space: 4 }) {
        Text(this.title).fontSize(13).fontColor(INK).fontWeight(FontWeight.Medium)
        Blank()
        Text(this.status)
          .fontSize(10)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.color)
          .padding({ left: 5, right: 5, top: 3, bottom: 3 })
          .backgroundColor(this.softColor)
          .borderRadius(8)
          .maxLines(1)
          .minFontSize(9).maxFontSize(10).maxFontScale(1.2)
      }.width('100%')
      Image(this.icon).width(38).height(34).objectFit(ImageFit.Contain)
      Text(this.value)
        .fontSize(23)
        .minFontSize(16)
        .maxFontSize(23)
        .maxLines(1)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.color)
      Text(this.label).fontSize(11).fontColor(MUTED).maxLines(2).height(28).lineHeight(14)
        .minFontSize(10).maxFontSize(11).maxFontScale(1.3)
    }
    .height(140)
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.SpaceBetween)
    .padding(12)
    .backgroundColor(GLASS)
    .borderRadius(22)
  }
}
